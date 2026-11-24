import AVFoundation

/// A camera file and when its first frame was captured on the host clock, if known.
struct CameraRecording: Sendable {
    let file: URL
    let start: CMTime?
}

/// Runs the capture session that the bubble shows and records, off the main thread. It
/// configures the session once per camera, reports when the first frame comes, and retries
/// once after a runtime error. The bubble draws the frames of its video data output: the
/// session has no preview connection to rebuild when the window moves or changes screen.
final class CameraCapture: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
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
    // On `frameQueue`.
    /// The time of the newest frame.
    private var lastFrame: Date?
    private var statsStart = Date()
    private var frameCount = 0
    private var longestGap: TimeInterval = 0
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
                CameraLog.note("session interrupted")
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
                CameraLog.note("session interruption ended")
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
                CameraLog.note("did not start running")
            }
        }
    }

    private func runtimeError(_ error: Error?) {
        CameraLog.error("runtime error: \(error.map { String(describing: $0) } ?? "unknown")")
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
        CameraLog.note("camera disconnected")
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
        CameraLog.error("failed: \(reason)")
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

    /// Shows the frame, and reports the first one of an attempt.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        display.show(sampleBuffer)
        let now = Date()
        let previous = lastFrame
        lastFrame = now
        if let previous {
            if CameraLog.isDebug {
                count(gap: now.timeIntervalSince(previous), at: now)
            }
            return
        }
        statsStart = now
        queue.async { [self] in
            guard seenAttempt != attempt else {
                return
            }
            seenAttempt = attempt
            report(.running)
        }
    }

    /// Every two seconds: how many frames came and the longest wait between two, which a
    /// frozen picture would show. A wait of over a quarter second is logged at once. Only with
    /// `DebugCamera`.
    private func count(gap: TimeInterval, at now: Date) {
        frameCount += 1
        longestGap = max(longestGap, gap)
        if gap > 0.25 {
            CameraLog.note("frame gap of \(Int(gap * 1000)) ms")
        }
        let elapsed = now.timeIntervalSince(statsStart)
        guard elapsed >= 2 else {
            return
        }
        CameraLog.note("\(String(format: "%.1f", Double(frameCount) / elapsed)) frames a second, longest gap \(Int(longestGap * 1000)) ms")
        frameCount = 0
        longestGap = 0
        statsStart = now
    }

    // MARK: Recording

    func startRecording(to file: URL) {
        queue.async { [self] in
            guard session.isRunning, !output.isRecording else {
                return
            }
            recordingStart = nil
            endedEarly = nil
            CameraLog.note("camera file starts")
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
        guard CameraLog.isDebug else {
            return
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { [self] in
            guard let pauseAsked else {
                return
            }
            let lag = (now - pauseAsked).seconds * 1000
            CameraLog.note("camera file \(change) \(String(format: "%.1f", lag)) ms after the clip")
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
            CameraLog.note("camera file ended after \(String(format: "%.2f", output.recordedDuration.seconds)) s\(error.map { ", error \($0.localizedDescription)" } ?? "")")
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
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            CameraLog.error("display stopped (status \(renderer.status.rawValue), error \(String(describing: renderer.error))); flushing")
            renderer.flush()
        }
        renderer.enqueue(frame)
    }
}
