import AppKit
import AVFoundation
import os
import ScreenCaptureKit
import VideoToolbox

/// Records one display, one window or an iPhone on a cable to an H.264 `.mp4` file, without
/// Tilde's own windows. The video leaves out the time spent paused.
final class ScreenRecorder: NSObject, SCStreamOutput, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Clip {
        let video: URL
        let seconds: Double
        /// The last frame, as PNG.
        let poster: Data?
    }

    enum Failure: Error {
        case notAllowed
        case noSource
        /// The screen sent no frame before the recording stopped.
        case noFrames
        /// The source's size cannot be written as H.264, such as 0 × 0.
        case badSize
    }

    /// Where recordings are kept until they are sent: `~/.tilde/recordings`.
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tilde/recordings", isDirectory: true)

    /// Where the frames come from: ScreenCaptureKit for the Mac, a capture session for a phone.
    private enum Capture {
        case stream(SCStream)
        case session(AVCaptureSession)
    }

    private let capture: Capture
    /// The clock of the frame times, which pauses are measured on.
    private let clock: CMClock
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "dev.tilde.recorder")
    private let log = Logger(subsystem: "dev.tilde.app", category: "recording")

    // Read and written on `queue` only.
    private var startTime: CMTime?
    private var pausedAt: CMTime?
    /// Time spent paused so far; frames are moved back by it.
    private var pausedTotal = CMTime.zero
    private var lastFrame: CVPixelBuffer?

    /// Starts recording a source.
    static func start(_ source: RecordingSource) async throws -> ScreenRecorder {
        let filter: SCContentFilter
        let size: CGSize
        switch source {
        case .phone(let phone):
            return try await start(phone)
        case .window(let window):
            let content = try await shareableContent()
            guard let shared = content.windows.first(where: { $0.windowID == CGWindowID(window.number) }) else {
                throw Failure.noSource
            }
            filter = SCContentFilter(desktopIndependentWindow: shared)
            size = shared.frame.size
        case .screen(let display):
            let content = try await shareableContent()
            guard let shared = content.displays.first(where: { $0.displayID == display }) ?? content.displays.first else {
                throw Failure.noSource
            }
            let tilde = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: shared, excludingApplications: tilde, exceptingWindows: [])
            size = shared.frame.size
        }

        // H.264 needs even sizes.
        let scale = CGFloat(filter.pointPixelScale)
        let width = Int(size.width * scale) / 2 * 2
        let height = Int(size.height * scale) / 2 * 2

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let (writer, input) = try makeWriter(width: width, height: height)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let recorder = ScreenRecorder(capture: .stream(stream), clock: CMClockGetHostTimeClock(), writer: writer, input: input)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
        return recorder
    }

    private static func start(_ phone: Phone) async throws -> ScreenRecorder {
        guard await PhoneCapture.isAllowed() else {
            throw Failure.notAllowed
        }
        guard let device = PhoneCapture.device(for: phone) else {
            throw Failure.noSource
        }
        let session = AVCaptureSession()
        let deviceInput = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
            throw Failure.noSource
        }
        session.addInput(deviceInput)
        session.addOutput(output)

        // The phone's format says 0 × 0 until it streams, so the first frame gives the size.
        let firstFrame = FirstFrame()
        output.setSampleBufferDelegate(firstFrame, queue: firstFrame.queue)
        session.startRunning()
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        do {
            let size = try await firstFrame.size(timeout: 5)
            (writer, input) = try makeWriter(width: Int(size.width) / 2 * 2, height: Int(size.height) / 2 * 2)
        } catch {
            session.stopRunning()
            throw error
        }
        let recorder = ScreenRecorder(capture: .session(session), clock: session.synchronizationClock ?? CMClockGetHostTimeClock(), writer: writer, input: input)
        output.setSampleBufferDelegate(recorder, queue: recorder.queue)
        return recorder
    }

    private static func shareableContent() async throws -> SCShareableContent {
        guard ScreenCapture.isAllowed else {
            throw Failure.notAllowed
        }
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// An H.264 writer for frames of this size, in `folder`. A size it cannot write is an error,
    /// not the exception that AVAssetWriterInput raises for it.
    static func makeWriter(width: Int, height: Int, in folder: URL = folder) throws -> (AVAssetWriter, AVAssetWriterInput) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
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

    private init(capture: Capture, clock: CMClock, writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.capture = capture
        self.clock = clock
        self.writer = writer
        self.input = input
    }

    private func stopCapture() async throws {
        switch capture {
        case .stream(let stream):
            try await stream.stopCapture()
        case .session(let session):
            session.stopRunning()
        }
    }

    func pause() {
        queue.async { [self] in
            if pausedAt == nil {
                pausedAt = now
            }
        }
    }

    func resume() {
        queue.async { [self] in
            if let pausedAt {
                pausedTotal = pausedTotal + (now - pausedAt)
                self.pausedAt = nil
            }
        }
    }

    /// Ends the recording and returns the finished clip.
    func stop() async throws -> Clip {
        try await stopCapture()
        let (start, end, lastFrame) = await withCheckedContinuation { continuation in
            queue.async { [self] in
                // A still screen sends no frames, so the clip lasts until now, less any pause.
                let end = (pausedAt ?? now) - pausedTotal
                continuation.resume(returning: (startTime, end, self.lastFrame))
            }
        }
        guard let start else {
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
            try? await stopCapture()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.isComplete(buffer) else {
            return
        }
        append(buffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(buffer)
    }

    /// Writes a frame, moved back by the time spent paused. Runs on `queue`.
    private func append(_ buffer: CMSampleBuffer) {
        guard pausedAt == nil, buffer.isValid, let frame = buffer.imageBuffer else {
            return
        }

        let time = buffer.presentationTimeStamp - pausedTotal
        if startTime == nil {
            startTime = time
            writer.startSession(atSourceTime: time)
        }
        guard input.isReadyForMoreMediaData else {
            return
        }

        var timing = CMSampleTimingInfo(duration: buffer.duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var moved: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &moved)
        guard let moved else {
            return
        }
        if !input.append(moved) {
            log.error("could not write a frame: \(self.writer.error?.localizedDescription ?? "", privacy: .public)")
        }
        lastFrame = frame
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

/// Waits for a capture session's first frame, for the size of the video.
private final class FirstFrame: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.tilde.recorder.first-frame")
    // Read and written on `queue` only.
    private var waiting: CheckedContinuation<CGSize, Error>?

    /// The first frame's size in pixels; `Failure.noFrames` when none comes in time.
    func size(timeout seconds: TimeInterval) async throws -> CGSize {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                waiting = continuation
                queue.asyncAfter(deadline: .now() + seconds) { [self] in
                    finish(with: .failure(ScreenRecorder.Failure.noFrames))
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let frame = buffer.imageBuffer else {
            return
        }
        finish(with: .success(CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))))
    }

    /// Runs on `queue`; only the first result counts.
    private func finish(with result: Result<CGSize, Error>) {
        waiting?.resume(with: result)
        waiting = nil
    }
}
