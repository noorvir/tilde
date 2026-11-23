import AppKit
import AVFoundation
import OSLog
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
    @Published fileprivate var cameraState: CameraCapture.State = .starting

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
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.barFollows() }
            },
        ]
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

/// A borderless panel that floats over other apps without taking the keyboard.
private final class BubblePanel: NSPanel {
    private let movesByDrag: Bool
    /// A press that did not move the panel.
    var onClick: () -> Void = {}

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
            let origin = frame.origin
            performDrag(with: event)
            if frame.origin == origin {
                onClick()
            }
            return
        }
        super.sendEvent(event)
    }
}

/// Notice and above, which release builds keep.
private let cameraLog = Logger(subsystem: "dev.tilde.app", category: "camera")

/// A camera file and when its first frame was captured on the host clock, if known.
struct CameraRecording: Sendable {
    let file: URL
    let start: CMTime?
}

/// Runs the capture session that the bubble shows and records, off the main thread. It
/// configures the session once per camera, reports when the first frame comes, and retries
/// once after a runtime error. The bubble draws the frames of its video data output: the
/// session has no preview connection to rebuild when the window moves or changes screen.
private final class CameraCapture: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State: Equatable {
        case starting, running, failed
    }

    let session = AVCaptureSession()
    /// The bubble's picture.
    let display = CameraDisplay()
    /// Called on the main thread.
    var onState: @MainActor (State) -> Void = { _ in }
    private let output = AVCaptureMovieFileOutput()
    /// The frames the bubble shows.
    private let frames = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dev.tilde.camera")
    private let frameQueue = DispatchQueue(label: "dev.tilde.camera.frames")
    private static let log = cameraLog
    /// The time of the newest frame; on `frameQueue`.
    private var lastFrame: Date?
    // Read and written on `queue`, except where noted.
    /// Waits for the file that `stopRecording` ends.
    private var finished: CheckedContinuation<CameraRecording?, Never>?
    /// When the file in progress started, on the host clock.
    private var recordingStart: CMTime?
    /// When the last pause or resume was asked for, on the host clock.
    private var pauseAsked: CMTime?
    /// A file that ended before `stopRecording`, such as when the camera went off or changed:
    /// `stopRecording` returns it.
    private var endedEarly: CameraRecording?
    private var cameraID: String?
    private var isWanted = false
    private var retried = false
    /// Counts starts, so a late frame or time limit of an earlier start does nothing.
    private var attempt = 0
    /// The attempt whose first frame came.
    private var seenAttempt = -1
    private var observers: [Any] = []

    /// The built-in camera, else an external one. A Continuity Camera only when chosen: it can
    /// take seconds to connect, or fail.
    static func defaultCamera() -> AVCaptureDevice? {
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        let external = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
        return builtIn.first ?? external.first
    }

    override init() {
        super.init()
        frames.alwaysDiscardsLateVideoFrames = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                self?.queue.async { self?.runtimeError(error) }
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in
                Self.log.notice("interrupted")
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
                Self.log.notice("interruption ended")
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
                let id = (note.object as? AVCaptureDevice)?.uniqueID
                self?.queue.async { self?.disconnected(id) }
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Runs the session on `cameraID`, or the default camera; does nothing while it already
    /// runs on that camera.
    func start(cameraID: String?) {
        queue.async { [self] in
            isWanted = true
            self.cameraID = cameraID
            retried = false
            run()
        }
    }

    /// Changes the camera; starts it only while the session is wanted.
    func use(cameraID: String?) {
        queue.async { [self] in
            self.cameraID = cameraID
            if isWanted {
                retried = false
                run()
            }
        }
    }

    /// Tries again after a failure.
    func retry() {
        queue.async { [self] in
            guard isWanted else {
                return
            }
            retried = false
            restart()
        }
    }

    func stop() {
        queue.async { [self] in
            isWanted = false
            attempt += 1
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: Starting, on `queue`

    private func run() {
        let device = cameraID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? Self.defaultCamera()
        guard let device else {
            fail("no camera")
            return
        }
        let current = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.uniqueID }
        if current == [device.uniqueID], session.isRunning {
            return
        }
        begin()
        if current != [device.uniqueID] {
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                fail("input: \(error.localizedDescription)")
                return
            }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                fail("cannot add input")
                return
            }
            session.addInput(input)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            if session.canAddOutput(frames) {
                session.addOutput(frames)
            }
            session.commitConfiguration()
        }
        startRunning()
    }

    /// Stops and starts the session on its camera again, with a fresh input.
    private func restart() {
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
        run()
    }

    /// A new attempt: the bubble shows a spinner until the first frame or the time limit.
    private func begin() {
        attempt += 1
        let attempt = attempt
        frames.setSampleBufferDelegate(self, queue: frameQueue)
        frameQueue.async { [self] in
            lastFrame = nil
        }
        report(.starting)
        queue.asyncAfter(deadline: .now() + 10) { [self] in
            if self.attempt == attempt, isWanted, seenAttempt != attempt {
                fail("no frame after 10 s")
            }
        }
    }

    private func startRunning() {
        if !session.isRunning {
            session.startRunning()
            if !session.isRunning {
                Self.log.notice("did not start running")
            }
        }
    }

    private func runtimeError(_ error: Error?) {
        Self.log.error("runtime error: \(error.map { String(describing: $0) } ?? "unknown", privacy: .public)")
        guard isWanted else {
            return
        }
        if retried {
            fail("runtime error after retry")
            return
        }
        retried = true
        restart()
    }

    private func disconnected(_ id: String?) {
        let current = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.uniqueID }
        guard let id, current.contains(id) else {
            return
        }
        Self.log.notice("camera disconnected")
        guard isWanted else {
            return
        }
        // The chosen camera is gone: the default one takes its place.
        if cameraID == id {
            cameraID = nil
        }
        restart()
    }

    private func fail(_ reason: String) {
        Self.log.error("failed: \(reason, privacy: .public)")
        attempt += 1
        report(.failed)
    }

    private func report(_ state: State) {
        let onState = onState
        Task { @MainActor in
            onState(state)
        }
    }

    // MARK: Frames, on `frameQueue`

    /// Shows the frame; logs a gap of over a second between frames, which a frozen picture
    /// would show.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        display.show(sampleBuffer)
        let now = Date()
        let previous = lastFrame
        lastFrame = now
        if let previous {
            let gap = now.timeIntervalSince(previous)
            if gap > 1 {
                Self.log.notice("frame gap of \(gap, format: .fixed(precision: 2), privacy: .public) s")
            }
            return
        }
        queue.async { [self] in
            guard seenAttempt != attempt else {
                return
            }
            seenAttempt = attempt
            report(.running)
        }
    }

    // MARK: Recording

    func startRecording(to file: URL) {
        queue.async { [self] in
            guard session.isRunning, !output.isRecording else {
                return
            }
            recordingStart = nil
            endedEarly = nil
            output.startRecording(to: file, recordingDelegate: self)
        }
    }

    func pauseRecording() {
        let asked = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { [self] in
            if output.isRecording {
                pauseAsked = asked
                output.pauseRecording()
            }
        }
    }

    func resumeRecording() {
        let asked = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { [self] in
            if output.isRecordingPaused {
                pauseAsked = asked
                output.resumeRecording()
            }
        }
    }

    /// The clip pauses and resumes when asked; the camera file does at its next frame. The
    /// two lags of a pause, less each other, are how far that pause moved the camera.
    func fileOutput(_ output: AVCaptureFileOutput, didPauseRecordingTo file: URL, from connections: [AVCaptureConnection]) {
        logLag("paused")
    }

    func fileOutput(_ output: AVCaptureFileOutput, didResumeRecordingTo file: URL, from connections: [AVCaptureConnection]) {
        logLag("resumed")
    }

    private func logLag(_ change: String) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { [self] in
            guard let pauseAsked else {
                return
            }
            let lag = (now - pauseAsked).seconds * 1000
            Self.log.notice("camera file \(change, privacy: .public) \(lag, format: .fixed(precision: 1), privacy: .public) ms after the clip")
        }
    }

    func stopRecording() async -> CameraRecording? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard output.isRecording else {
                    continuation.resume(returning: endedEarly)
                    endedEarly = nil
                    return
                }
                finished = continuation
                output.stopRecording()
            }
        }
    }

    /// The file's first frame, as the session's clock gives it (macOS 15 and later).
    @available(macOS 15.0, *)
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo file: URL, startPTS: CMTime, from connections: [AVCaptureConnection]) {
        let start = CMSyncConvertTime(startPTS, from: session.synchronizationClock ?? CMClockGetHostTimeClock(), to: CMClockGetHostTimeClock())
        queue.async { [self] in
            recordingStart = start
        }
    }

    /// Before macOS 15: the time recording began, a frame or so before its first frame.
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo file: URL, from connections: [AVCaptureConnection]) {
        let start = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { [self] in
            if recordingStart == nil {
                recordingStart = start
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo file: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async { [self] in
            // A file cut short by an error or by the camera going off can still play, and stays
            // beside its clip; one with no frames cannot.
            let hasFrames = output.recordedDuration.seconds > 0
            if !hasFrames {
                try? FileManager.default.removeItem(at: file)
            }
            let recording = hasFrames ? CameraRecording(file: file, start: recordingStart) : nil
            if let finished {
                finished.resume(returning: recording)
                self.finished = nil
            } else {
                endedEarly = recording
            }
        }
    }
}

// MARK: - Views

private struct CameraBubbleView: View {
    @ObservedObject var bubble: CameraBubble
    let display: CameraDisplay

    var body: some View {
        let clip = bubble.shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: bubble.side * 0.2))
        ZStack {
            Color.tildeInk
            if bubble.isDenied {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: bubble.side * 0.2))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                CameraPreview(display: display)
                switch bubble.cameraState {
                case .starting:
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                case .failed:
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16))
                        Text("Camera did not start")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Click to retry")
                            .font(.system(size: 10.5))
                            .opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.tildeInk)
                case .running:
                    EmptyView()
                }
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
    let display: CameraDisplay

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(display: display)
    }

    func updateNSView(_ view: PreviewView, context: Context) {}

    /// The camera's picture, filling the view from its centre, as a mirror.
    final class PreviewView: NSView {
        private let display: CameraDisplay

        init(display: CameraDisplay) {
            self.display = display
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(display.layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            display.layer.bounds = CGRect(origin: .zero, size: bounds.size)
            display.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }
}

/// Shows camera frames as they come, from any one queue at a time, mirrored. It needs no
/// main thread and no capture connection, so a window move or a busy main thread does not
/// stop it.
final class CameraDisplay: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()

    init() {
        layer.videoGravity = .resizeAspectFill
        layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
    }

    func show(_ frame: CMSampleBuffer) {
        // A live frame shows now, not at its time stamp on a timebase the layer does not have.
        if !frame.sampleAttachments.isEmpty {
            frame.sampleAttachments[0][.displayImmediately] = true
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            cameraLog.error("camera display failed: \(String(describing: renderer.error), privacy: .public); flushing")
            renderer.flush()
        }
        renderer.enqueue(frame)
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
                MenuRow(symbol: "mic", title: microphone.localizedName, isOn: microphone.uniqueID == bubble.currentMicrophoneID) {
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
