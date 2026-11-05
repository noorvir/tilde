import AppKit
import AVFoundation
import os
import ScreenCaptureKit
import VideoToolbox

/// Records one display, one window or an iPhone on a cable to an H.264 `.mp4` file, without
/// Tilde's own windows other than its browser. The video leaves out the time spent paused.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Clip {
        let video: URL
        let seconds: Double
        /// The last frame, as PNG.
        let poster: Data?
    }

    enum Failure: Error {
        case notAllowed
        /// The window, display or phone is not there any more.
        case noSource
        /// The screen sent no frame before the recording stopped.
        case noFrames
        /// The source's size cannot be written as H.264, such as 0 × 0.
        case badSize
    }

    /// The longest side of a video, in pixels. An agent needs no more, hardware H.264 encoders
    /// take at most 4096 (above it macOS encodes in software, slowly), and a smaller file goes
    /// faster to other machines. ScreenCaptureKit scales the frames on the GPU.
    static let maxSide: CGFloat = 2560

    /// Called once, on the recorder's queue, when the source stops sending by itself: the
    /// window closed, the display went away, sharing was stopped, or the phone was unplugged.
    private let onSourceEnded: @Sendable () -> Void

    /// Where the frames come from: ScreenCaptureKit for the Mac, a capture session for a phone.
    private enum Capture {
        case stream(SCStream)
        case session(AVCaptureSession, observers: [NSObjectProtocol])
    }

    /// Set once, right after the recorder exists, as the stream needs it as its delegate.
    private var capture: Capture?
    /// What a stream records, to take a picture of it at Resume; a phone streams all the time.
    private var stillSource: (filter: SCContentFilter, configuration: SCStreamConfiguration)?
    /// The clock of the frame times, which pauses are measured on.
    private let clock: CMClock
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "dev.tilde.recorder")
    private let writerWatch: DispatchSourceTimer
    private let log = Logger(subsystem: "dev.tilde.app", category: "recording")

    // Read and written on `queue` only.
    private var startTime: CMTime?
    /// The time of the last frame written, in the video's time.
    private var lastTime: CMTime?
    private var lastFrame: CVPixelBuffer?
    /// The pauses, in frame time; the last one is open while paused. A frame captured during
    /// a pause is never written.
    private var pauses: [(start: CMTime, end: CMTime?)] = []
    private var hasSourceEnded = false

    /// Starts recording a source into `video`. `browserWindow`, Tilde's browser, stays in a
    /// recording of the screen; Tilde's other windows do not.
    static func start(
        _ source: RecordingSource, to video: URL, browserWindow: Int?, onSourceEnded: @escaping @Sendable () -> Void
    ) async throws -> ScreenRecorder {
        let filter: SCContentFilter
        let size: CGSize
        switch source {
        case .phone(let phone):
            return try await start(phone, to: video, onSourceEnded: onSourceEnded)
        case .window(let window):
            let content = try await shareableContent()
            guard let shared = content.windows.first(where: { $0.windowID == CGWindowID(window.number) }) else {
                throw Failure.noSource
            }
            filter = SCContentFilter(desktopIndependentWindow: shared)
            size = shared.frame.size
        case .screen(let display):
            let content = try await shareableContent()
            guard let shared = content.displays.first(where: { $0.displayID == display }) else {
                throw Failure.noSource
            }
            let tilde = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let browser = content.windows.filter { Int($0.windowID) == browserWindow }
            filter = SCContentFilter(display: shared, excludingApplications: tilde, exceptingWindows: browser)
            size = shared.frame.size
        }

        let scale = CGFloat(filter.pointPixelScale)
        let (width, height) = videoSize(of: CGSize(width: size.width * scale, height: size.height * scale))
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let (writer, input) = try makeWriter(width: width, height: height, to: video)
        let recorder = ScreenRecorder(clock: CMClockGetHostTimeClock(), writer: writer, input: input, onSourceEnded: onSourceEnded)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: recorder)
        recorder.capture = .stream(stream)
        recorder.stillSource = (filter, configuration)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        do {
            try await stream.startCapture()
        } catch {
            recorder.discard()
            throw error
        }
        return recorder
    }

    private static func start(_ phone: Phone, to video: URL, onSourceEnded: @escaping @Sendable () -> Void) async throws -> ScreenRecorder {
        let (session, device, output) = try await PhoneCapture.session(for: phone)
        let firstFrame = FirstFrame()
        output.setSampleBufferDelegate(firstFrame, queue: firstFrame.queue)
        session.startRunning()
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        do {
            let frame = try await firstFrame.image(timeout: 5)
            let (width, height) = videoSize(of: CGSize(width: frame.width, height: frame.height))
            (writer, input) = try makeWriter(width: width, height: height, to: video)
        } catch {
            session.stopRunning()
            throw error
        }

        let recorder = ScreenRecorder(
            clock: session.synchronizationClock ?? CMClockGetHostTimeClock(), writer: writer, input: input, onSourceEnded: onSourceEnded
        )
        let center = NotificationCenter.default
        let ended: @Sendable (Notification) -> Void = { [weak recorder] _ in
            recorder?.queue.async { [weak recorder] in
                recorder?.sourceEnded()
            }
        }
        recorder.capture = .session(session, observers: [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil, using: ended),
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil, using: ended),
        ])
        output.setSampleBufferDelegate(recorder, queue: recorder.queue)
        return recorder
    }

    private static func shareableContent() async throws -> SCShareableContent {
        guard ScreenCapture.isAllowed else {
            throw Failure.notAllowed
        }
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// The video's size for a source of these pixels: at most `maxSide` on the long side, in
    /// proportion, and even, as H.264 needs.
    static func videoSize(of pixels: CGSize) -> (width: Int, height: Int) {
        let scale = min(1, maxSide / max(pixels.width, pixels.height, 1))
        return (Int(pixels.width * scale) / 2 * 2, Int(pixels.height * scale) / 2 * 2)
    }

    /// An H.264 writer for frames of this size into `video`. A frame of another size, such as
    /// a phone turned sideways, is fitted in with bars. A size it cannot write is an error, not
    /// the exception that AVAssetWriterInput raises for it.
    static func makeWriter(width: Int, height: Int, to video: URL) throws -> (AVAssetWriter, AVAssetWriterInput) {
        let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw Failure.badSize
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? Failure.noSource
        }
        return (writer, input)
    }

    private init(clock: CMClock, writer: AVAssetWriter, input: AVAssetWriterInput, onSourceEnded: @escaping @Sendable () -> Void) {
        self.clock = clock
        self.writer = writer
        self.input = input
        self.onSourceEnded = onSourceEnded
        writerWatch = DispatchSource.makeTimerSource(queue: queue)
        super.init()
        // A writer can fail while it takes no frames, or while none come: each second it is
        // checked, and a failed one ends the clip.
        writerWatch.schedule(deadline: .now() + 1, repeating: 1)
        writerWatch.setEventHandler { [weak self] in
            if self?.writer.status == .failed {
                self?.sourceEnded()
            }
        }
        writerWatch.resume()
    }

    private func stopCapture() async {
        writerWatch.cancel()
        switch capture {
        case .stream(let stream):
            try? await stream.stopCapture()
        case .session(let session, let observers):
            observers.forEach(NotificationCenter.default.removeObserver)
            session.stopRunning()
        case nil:
            break
        }
    }

    func pause() {
        queue.async { [self] in
            if pauses.last.map({ $0.end != nil }) ?? true {
                pauses.append((now, nil))
            }
        }
    }

    func resume() {
        queue.async { [self] in
            guard let open = pauses.last, open.end == nil else {
                return
            }
            pauses[pauses.count - 1].end = now
            writeStill()
        }
    }

    /// A screen sends frames only when it changes: after Resume, a picture taken now shows it
    /// as it is, also when it does not change.
    private func writeStill() {
        guard let stillSource else {
            return
        }
        Task { [self] in
            guard let buffer = try? await SCScreenshotManager.captureSampleBuffer(contentFilter: stillSource.filter, configuration: stillSource.configuration) else {
                return
            }
            let still = Still(buffer: buffer)
            queue.async { [self] in
                writeUntilAccepted(still, takenAt: now, tries: 20)
            }
        }
    }

    /// A picture handed to the recorder's queue; a sample buffer does not change once made.
    private struct Still: @unchecked Sendable {
        let buffer: CMSampleBuffer
    }

    /// A busy encoder can refuse the picture; it is offered again until it is written, a newer
    /// frame is, or a pause began after it was taken.
    private func writeUntilAccepted(_ still: Still, takenAt: CMTime, tries: Int) {
        guard let time = videoTime(of: takenAt), lastTime.map({ time > $0 }) ?? true, tries > 0 else {
            return
        }
        guard write(still.buffer, at: time) else {
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                writeUntilAccepted(still, takenAt: takenAt, tries: tries - 1)
            }
            return
        }
    }

    var video: URL {
        writer.outputURL
    }

    /// Ends the recording and returns the finished clip.
    func stop() async throws -> Clip {
        await stopCapture()
        let (start, end, lastFrame) = await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: (startTime, endTime, self.lastFrame))
            }
        }
        guard let start, end > start else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            throw Failure.noFrames
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if let error = writer.error {
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: writer.outputURL.path)

        var poster: Data?
        if let lastFrame {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(lastFrame, options: nil, imageOut: &image)
            poster = image.flatMap { ScreenCapture.png(from: $0, outline: nil, scale: 1, maxSide: 1600) }
        }
        return Clip(video: writer.outputURL, seconds: (end - start).seconds, poster: poster)
    }

    /// Ends the recording and deletes its file.
    func discard() {
        Task {
            await stopCapture()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
        }
    }

    // MARK: - Frames (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.isComplete(buffer) else {
            return
        }
        append(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.notice("recorded source stopped: \(error.localizedDescription, privacy: .public)")
        queue.async { [self] in
            sourceEnded()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(buffer)
    }

    private func sourceEnded() {
        guard !hasSourceEnded else {
            return
        }
        hasSourceEnded = true
        onSourceEnded()
    }

    /// Writes a frame moved back by the time spent paused before it; one captured during a
    /// pause, also one that arrives late, is dropped.
    private func append(_ buffer: CMSampleBuffer) {
        guard buffer.isValid, buffer.imageBuffer != nil, let time = videoTime(of: buffer.presentationTimeStamp) else {
            return
        }
        write(buffer, at: time)
    }

    /// The video time of a frame time, or nil when it is inside a pause. Pauses are decided by
    /// the frame's own time, as frames can arrive after the pause or resume that follows them.
    private func videoTime(of frameTime: CMTime) -> CMTime? {
        var paused = CMTime.zero
        for pause in pauses where frameTime >= pause.start {
            guard let end = pause.end, frameTime >= end else {
                return nil
            }
            paused = paused + (end - pause.start)
        }
        return frameTime - paused
    }

    /// Writes a frame at a video time after the last one; AVAssetWriter refuses a time that
    /// goes back, and the whole clip with it. Returns false when the encoder is busy.
    @discardableResult
    private func write(_ buffer: CMSampleBuffer, at time: CMTime) -> Bool {
        guard lastTime.map({ time > $0 }) ?? true, let frame = buffer.imageBuffer else {
            return true
        }
        if startTime == nil {
            startTime = time
            writer.startSession(atSourceTime: time)
        }
        guard input.isReadyForMoreMediaData else {
            return false
        }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var moved: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &moved)
        guard let moved, input.append(moved) else {
            log.error("could not write a frame: \(self.writer.error?.localizedDescription ?? "", privacy: .public)")
            // A writer that failed takes no more frames: the clip ends, and Stop reports it.
            if writer.status == .failed {
                sourceEnded()
            }
            return true
        }
        lastTime = time
        lastFrame = frame
        return true
    }

    /// Where the clip ends: a source that went away at its last frame; else now (a still
    /// screen sends no frames, so the clip lasts until Stop), or the start of an open pause.
    private var endTime: CMTime {
        if hasSourceEnded, let lastTime {
            return lastTime + CMTime(value: 1, timescale: 30)
        }
        let stoppedAt = pauses.last.flatMap { $0.end == nil ? $0.start : nil } ?? now
        var paused = CMTime.zero
        for pause in pauses {
            if let end = pause.end {
                paused = paused + (end - pause.start)
            }
        }
        return stoppedAt - paused
    }

    /// Whether the buffer holds a new frame; ScreenCaptureKit also sends idle ones.
    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let status = (attachments?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        return status == .complete
    }

    private var now: CMTime {
        CMClockGetTime(clock)
    }
}
