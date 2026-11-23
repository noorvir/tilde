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

    private let defaults: UserDefaults
    private let capture = CameraCapture()
    private var bubblePanel: BubblePanel?
    private var barPanel: BubblePanel?
    private var isShown = false
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
    }

    var side: CGFloat {
        Self.sizes[sizeIndex].side
    }

    /// The bubble shows, so a clip that starts now records the camera.
    var isShowing: Bool {
        isShown && isOn
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
        return AVCaptureDevice.default(for: .video)?.uniqueID ?? all.first?.uniqueID
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

    /// The finished camera file, or nil when it recorded nothing.
    func stopRecording() async -> URL? {
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
        let shows = isRecordMode && isOn
        guard shows != isShown || showsBar != self.showsBar else {
            return
        }
        isShown = shows
        self.showsBar = showsBar
        if !showsBar {
            openMenu = nil
        }
        refresh()
    }

    private func refresh() {
        guard isShown, isOn else {
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
        if granted, isShown {
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
        panel.contentView = NSHostingView(rootView: CameraBubbleView(bubble: self, session: capture.session))
        bubblePanel = panel
        return panel
    }

    private func makeBarPanel() -> BubblePanel {
        let panel = BubblePanel(frame: .zero, movesByDrag: false)
        panel.contentView = FirstMouseHostingView(rootView: CameraBubbleBar(bubble: self))
        barPanel = panel
        return panel
    }

    /// The bar centred under the bubble; an open menu grows it upward, over the bubble.
    private func layoutBar() {
        guard let barPanel, let bubblePanel, let content = barPanel.contentView else {
            return
        }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let barTop = bubblePanel.frame.minY - 8
        let origin = NSPoint(x: (bubblePanel.frame.midX - size.width / 2).rounded(), y: barTop - HUDAccessory.size.height)
        barPanel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// A borderless panel that floats over other apps without taking the keyboard.
private final class BubblePanel: NSPanel {
    private let movesByDrag: Bool

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
        if movesByDrag, event.type == .leftMouseDown {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
}

/// Runs the capture session that the bubble shows and records, off the main thread.
private final class CameraCapture: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "dev.tilde.camera")
    /// Waits for the file that `stopRecording` ends; read and written on `queue`.
    private var finished: CheckedContinuation<URL?, Never>?

    func start(cameraID: String?) {
        use(cameraID: cameraID)
        queue.async { [self] in
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func use(cameraID: String?) {
        queue.async { [session] in
            let device = cameraID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
            let current = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.uniqueID }
            guard let device, current != [device.uniqueID], let input = try? AVCaptureDeviceInput(device: device) else {
                return
            }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func startRecording(to file: URL) {
        queue.async { [self] in
            guard session.isRunning, !output.isRecording else {
                return
            }
            output.startRecording(to: file, recordingDelegate: self)
        }
    }

    func pauseRecording() {
        queue.async { [output] in
            if output.isRecording {
                output.pauseRecording()
            }
        }
    }

    func resumeRecording() {
        queue.async { [output] in
            if output.isRecordingPaused {
                output.resumeRecording()
            }
        }
    }

    func stopRecording() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard output.isRecording else {
                    continuation.resume(returning: nil)
                    return
                }
                finished = continuation
                output.stopRecording()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo file: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async { [self] in
            // A file cut short by an error can still play; one with no frames cannot.
            finished?.resume(returning: output.recordedDuration.seconds > 0 ? file : nil)
            finished = nil
        }
    }
}

// MARK: - Views

private struct CameraBubbleView: View {
    @ObservedObject var bubble: CameraBubble
    let session: AVCaptureSession

    var body: some View {
        let clip = bubble.shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: bubble.side * 0.2))
        ZStack {
            Color.tildeInk
            if bubble.isDenied {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: bubble.side * 0.2))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                CameraPreview(session: session)
            }
        }
        .frame(width: bubble.side, height: bubble.side)
        .clipShape(clip)
        .overlay(clip.stroke(Color.white.opacity(0.9), lineWidth: 3))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Camera")
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(session: session)
    }

    func updateNSView(_ view: PreviewView, context: Context) {}

    /// The camera's picture, filling the view from its centre, as a mirror.
    final class PreviewView: NSView {
        private let preview: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            wantsLayer = true
            preview.videoGravity = .resizeAspectFill
            preview.connection?.automaticallyAdjustsVideoMirroring = false
            preview.connection?.isVideoMirrored = true
            layer?.addSublayer(preview)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Under the bubble: camera and microphone menus, shape, size, and camera off.
private struct CameraBubbleBar: View {
    @ObservedObject var bubble: CameraBubble

    var body: some View {
        let size = HUDAccessory.size
        VStack(alignment: .center, spacing: 8) {
            switch bubble.openMenu {
            case .camera: cameraMenu
            case .microphone: microphoneMenu
            case .size: sizeMenu
            case nil: EmptyView()
            }
            HStack(spacing: size.scaled(2)) {
                menuButton(image: Image(systemName: "video.fill"), menu: .camera, help: "Camera")
                menuButton(image: Image(systemName: bubble.isMicrophoneOn ? "mic.fill" : "mic.slash.fill"), menu: .microphone, help: "Microphone")
                HUDBarDivider()
                HUDButton(image: Image(systemName: bubble.shape == .circle ? "circle" : "app"), help: "Shape") {
                    bubble.toggleShape()
                }
                sizeButton
                HUDBarDivider()
                HUDButton(image: Image(systemName: "xmark"), help: "Turn camera off") {
                    bubble.toggle()
                }
            }
            .pillInsets(size)
            .pill()
        }
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }

    private func menuButton(image: Image?, title: String? = nil, menu: CameraBubble.Menu, help: String) -> some View {
        Button {
            bubble.toggleMenu(menu)
        } label: {
            HUDButtonLabel(image: image, title: title, opensBelow: true)
                .modifier(HUDButtonChrome(isActive: bubble.openMenu == menu, padding: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
    }

    private var cameraMenu: some View {
        MenuCard {
            ForEach(bubble.cameras, id: \.uniqueID) { camera in
                MenuRow(symbol: "video", title: camera.localizedName, isOn: camera.uniqueID == bubble.currentCameraID) {
                    bubble.chooseCamera(camera.uniqueID)
                }
            }
        }
    }

    private var microphoneMenu: some View {
        MenuCard {
            MenuRow(symbol: "mic", title: "Record microphone", isOn: bubble.isMicrophoneOn) {
                bubble.toggleMicrophone()
            }
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.vertical, 3).padding(.horizontal, 6)
            ForEach(bubble.microphones, id: \.uniqueID) { microphone in
                MenuRow(symbol: "waveform", title: microphone.localizedName, isOn: microphone.uniqueID == bubble.currentMicrophoneID) {
                    bubble.chooseMicrophone(microphone.uniqueID)
                }
            }
        }
    }

    /// The current size's icon; grey while its sizes show.
    private var sizeButton: some View {
        let name = CameraBubble.sizes[bubble.sizeIndex].name
        return Button {
            bubble.toggleMenu(.size)
        } label: {
            SizeIcon(shape: bubble.shape, index: bubble.sizeIndex)
                .modifier(HUDButtonChrome(isOn: bubble.openMenu == .size))
        }
        .buttonStyle(.plain)
        .tildeTooltip(bubble.openMenu == .size ? nil : "Size: \(name)")
        .accessibilityLabel("Size")
        .accessibilityValue(name)
    }

    /// A row of the sizes, each drawn as the bubble's shape at that size.
    private var sizeMenu: some View {
        let size = HUDAccessory.size
        return HStack(spacing: size.scaled(2)) {
            ForEach(CameraBubble.sizes.indices, id: \.self) { index in
                let name = CameraBubble.sizes[index].name
                Button {
                    bubble.chooseSize(index)
                } label: {
                    SizeIcon(shape: bubble.shape, index: index)
                        .modifier(HUDButtonChrome(isOn: index == bubble.sizeIndex))
                }
                .buttonStyle(.plain)
                .tildeTooltip(name)
                .accessibilityLabel(name)
                .accessibilityAddTraits(index == bubble.sizeIndex ? .isSelected : [])
            }
        }
        .padding(size.scaled(4))
        .hudCard(cornerRadius: size.scaled(12))
        .environment(\.pillSize, size)
    }
}

/// The bubble's shape drawn small, medium or large, in a frame of the largest.
private struct SizeIcon: View {
    let shape: CameraBubble.Shape
    let index: Int
    @Environment(\.pillSize) private var pillSize

    var body: some View {
        let side = pillSize.scaled([7, 10, 13][min(index, 2)])
        let frame = pillSize.scaled(14)
        Group {
            if shape == .circle {
                Circle().strokeBorder(lineWidth: 1.5)
            } else {
                RoundedRectangle(cornerRadius: side * 0.28).strokeBorder(lineWidth: 1.5)
            }
        }
        .frame(width: side, height: side)
        .frame(width: frame, height: frame)
    }
}

/// A HUD card of rows, as the source dropdown.
struct MenuCard<Content: View>: View {
    var width: CGFloat = 260
    @ViewBuilder let content: () -> Content

    var body: some View {
        let size = HUDAccessory.size
        VStack(spacing: size.scaled(2)) {
            content()
        }
        .frame(width: width)
        .padding(size.scaled(4))
        .hudCard(cornerRadius: size.scaled(12))
        .environment(\.pillSize, size)
    }
}

/// A row of a HUD card: grey with a check mark while it is the current choice.
struct MenuRow: View {
    let symbol: String
    let title: String
    var isOn = false
    var width: CGFloat = 260
    let action: () -> Void

    var body: some View {
        let size = HUDAccessory.size
        Button(action: action) {
            HStack(spacing: size.scaled(4)) {
                HUDButtonLabel(image: Image(systemName: symbol), title: title, fillsWidth: true)
                Image(systemName: "checkmark")
                    .font(.system(size: size.font(10.5), weight: .semibold))
                    .opacity(isOn ? 1 : 0)
            }
            .modifier(HUDButtonChrome(width: width, isOn: isOn, padding: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
