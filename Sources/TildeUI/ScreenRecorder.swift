import AppKit
import AVFoundation
import os
import ScreenCaptureKit
import VideoToolbox

/// Records one display, one window or an iPhone on a cable to an H.264 `.mp4` file, without
/// Tilde's own windows other than its browser on a display, and with the microphone
/// when asked (macOS 15 and later). The video leaves out the time spent paused.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Clip {
        let video: URL
        let seconds: Double
        /// The last frame, as PNG.
        let poster: Data?
        /// When the first frame was captured, on the host clock: the clip's time zero, which
        /// its sound is written against too, and the camera is aligned to.
        let start: CMTime
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

    /// Ends the source the frames come from: ScreenCaptureKit for the Mac, a capture session
    /// for a phone. Set once, right after the recorder exists, as the stream needs it as its
    /// delegate.
    private var endCapture: () async -> Void = {}
    /// For a window's clip, which captures an area of its display: moves that area to where the
    /// window is now, a frame in Quartz coordinates.
    private var moveArea: (CGRect) -> Void = { _ in }
    /// Takes a picture of what a stream records, at Resume; a phone streams all the time.
    private var takeStill: (@Sendable () async -> CMSampleBuffer?)?
    /// The clock of the frame times, which pauses are measured on.
    private let clock: CMClock
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    /// The microphone's track; nil when the clip has no sound.
    private let audioInput: AVAssetWriterInput?
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
    /// Counts each pause and resume: a Resume still belongs to the stretch of recording it
    /// was taken for, and is dropped once that stretch is over.
    private var interval = 0
    /// Set by Stop and Discard: from then on nothing is written.
    private var isStopped = false

    /// Starts recording a source into `video`. Of Tilde's windows, only `browserWindow`, the
    /// number of Tilde's browser window, shows in a display's clip; a window's clip shows that
    /// window's app alone. `microphone`: the `AVCaptureDevice.uniqueID` whose sound the clip
    /// records, or nil for none. The camera is a file of its own.
    static func start(
        _ source: RecordingSource, to video: URL, browserWindow: Int?, microphone: String?, onSourceEnded: @escaping @Sendable () -> Void
    ) async throws -> ScreenRecorder {
        let filter: SCContentFilter
        let size: CGSize
        /// A window's place on its display, and the display's frame.
        var windowArea: (rect: CGRect, display: CGRect, offset: CGVector)?
        switch source {
        case .phone(let phone):
            return try await start(phone, to: video, onSourceEnded: onSourceEnded)
        case .window(let window):
            let content = try await shareableContent()
            guard let shared = content.windows.first(where: { $0.windowID == CGWindowID(window.number) }),
                  let (showing, display) = ScreenCapture.filter(showingAppOf: shared, at: shared.frame, content: content)
            else {
                throw Failure.noSource
            }
            let area = shared.frame.intersection(display)
            filter = showing
            size = area.size
            windowArea = (area, display, CGVector(dx: area.minX - shared.frame.minX, dy: area.minY - shared.frame.minY))
        case .screen(let display):
            let content = try await shareableContent()
            guard let shared = content.displays.first(where: { $0.displayID == display }) else {
                throw Failure.noSource
            }
            let tilde = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let kept = content.windows.filter { Int($0.windowID) == browserWindow }
            filter = SCContentFilter(display: shared, excludingApplications: tilde, exceptingWindows: kept)
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
        if let windowArea {
            configuration.sourceRect = windowArea.rect.offsetBy(dx: -windowArea.display.minX, dy: -windowArea.display.minY)
        }

        var recordsMicrophone = false
        if #available(macOS 15.0, *), let microphone {
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = microphone
            recordsMicrophone = true
        }

        let (writer, input, audioInput) = try makeWriter(width: width, height: height, withAudio: recordsMicrophone, to: video)
        let recorder = ScreenRecorder(clock: CMClockGetHostTimeClock(), writer: writer, input: input, audioInput: audioInput, onSourceEnded: onSourceEnded)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: recorder)
        recorder.endCapture = {
            try? await stream.stopCapture()
        }
        if let windowArea {
            recorder.moveArea = { [stream] frame in
                let origin = CGPoint(x: frame.minX + windowArea.offset.dx - windowArea.display.minX, y: frame.minY + windowArea.offset.dy - windowArea.display.minY)
                let moved = SCStreamConfiguration()
                moved.width = configuration.width
                moved.height = configuration.height
                moved.minimumFrameInterval = configuration.minimumFrameInterval
                moved.showsCursor = true
                moved.pixelFormat = configuration.pixelFormat
                moved.sourceRect = CGRect(origin: origin, size: windowArea.rect.size)
                // A new configuration has no microphone: the sound would stop.
                if #available(macOS 15.0, *), let microphone {
                    moved.captureMicrophone = true
                    moved.microphoneCaptureDeviceID = microphone
                }
                stream.updateConfiguration(moved) { _ in }
            }
        }
        recorder.takeStill = { [filter, configuration] in
            try? await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration)
        }
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        if #available(macOS 15.0, *), microphone != nil {
            try stream.addStreamOutput(recorder, type: .microphone, sampleHandlerQueue: recorder.queue)
        }
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
            (writer, input, _) = try makeWriter(width: width, height: height, withAudio: false, to: video)
        } catch {
            session.stopRunning()
            throw error
        }

        let recorder = ScreenRecorder(
            clock: session.synchronizationClock ?? CMClockGetHostTimeClock(), writer: writer, input: input, audioInput: nil, onSourceEnded: onSourceEnded
        )
        let center = NotificationCenter.default
        let ended: @Sendable (Notification) -> Void = { [weak recorder] _ in
            recorder?.queue.async { [weak recorder] in
                recorder?.sourceEnded()
            }
        }
        let observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil, using: ended),
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil, using: ended),
        ]
        recorder.endCapture = {
            observers.forEach(center.removeObserver)
            session.stopRunning()
        }
        output.setSampleBufferDelegate(recorder, queue: recorder.queue)
        return recorder
    }

    private static func shareableContent() async throws -> SCShareableContent {
        guard ScreenCapture.isAllowed else {
            throw Failure.notAllowed
        }
        // All apps with windows: a window clip leaves out the apps of this list for as long as
        // it records, also those with no window on screen when it starts.
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    /// The video's size for a source of these pixels: at most `maxSide` on the long side, in
    /// proportion, and even, as H.264 needs.
    static func videoSize(of pixels: CGSize) -> (width: Int, height: Int) {
        let scale = min(1, maxSide / max(pixels.width, pixels.height, 1))
        return (Int(pixels.width * scale) / 2 * 2, Int(pixels.height * scale) / 2 * 2)
    }

    /// An H.264 writer for frames of this size into `video`, with an AAC track when
    /// `withAudio`. A frame of another size, such as a phone turned sideways, is fitted in
    /// with bars. A size it cannot write is an error, not the exception that
    /// AVAssetWriterInput raises for it.
    static func makeWriter(
        width: Int, height: Int, withAudio: Bool, to video: URL
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput?) {
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
        var audioInput: AVAssetWriterInput?
        if withAudio {
            let audio = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000, AVEncoderBitRateKey: 96000]
            )
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            audioInput = audio
        }
        guard writer.startWriting() else {
            throw writer.error ?? Failure.noSource
        }
        return (writer, input, audioInput)
    }

    private init(
        clock: CMClock, writer: AVAssetWriter, input: AVAssetWriterInput, audioInput: AVAssetWriterInput?, onSourceEnded: @escaping @Sendable () -> Void
    ) {
        self.clock = clock
        self.writer = writer
        self.input = input
        self.audioInput = audioInput
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
        await endCapture()
    }

    /// A window's clip keeps to the window where it moved, `frame` in Quartz coordinates, on
    /// the display that it started on.
    func follow(windowFrame frame: CGRect) {
        moveArea(frame)
    }

    func pause() {
        queue.async { [self] in
            if pauses.last.map({ $0.end != nil }) ?? true {
                pauses.append((now, nil))
                interval += 1
            }
        }
    }

    func resume() {
        queue.async { [self] in
            guard let open = pauses.last, open.end == nil else {
                return
            }
            pauses[pauses.count - 1].end = now
            interval += 1
            writeStill(for: interval)
        }
    }

    /// A screen sends frames only when it changes: after Resume, a picture taken now shows it
    /// as it is, also when it does not change. It goes in at the time it was taken, and only
    /// while the recording it was taken for goes on.
    private func writeStill(for interval: Int) {
        guard let takeStill else {
            return
        }
        Task { [weak self] in
            let buffer = await takeStill()
            guard let buffer, buffer.presentationTimeStamp.isValid, let self else {
                return
            }
            let still = Still(buffer: buffer)
            queue.async { [weak self] in
                self?.writeUntilAccepted(still, interval: interval)
            }
        }
    }

    /// A picture handed to the recorder's queue; a sample buffer does not change once made.
    private struct Still: @unchecked Sendable {
        let buffer: CMSampleBuffer
    }

    /// A busy encoder can refuse the picture; it is offered again until it is written, a newer
    /// frame is, or its stretch of recording ended (a pause, Stop or Discard).
    private func writeUntilAccepted(_ still: Still, interval: Int) {
        guard interval == self.interval, !isStopped, let time = videoTime(of: still.buffer.presentationTimeStamp), lastTime.map({ time > $0 }) ?? true else {
            return
        }
        guard write(still.buffer, at: time) else {
            queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.writeUntilAccepted(still, interval: interval)
            }
            return
        }
    }

    var video: URL {
        writer.outputURL
    }

    /// Ends the recording and returns the finished clip.
    func stop() async throws -> Clip {
        // The clip ends now: frames and Resume pictures that come while the capture shuts down
        // can show what the user put on screen after Stop.
        let (start, end, lastFrame) = await withCheckedContinuation { continuation in
            queue.async { [self] in
                isStopped = true
                continuation.resume(returning: (startTime, endTime, self.lastFrame))
            }
        }
        await stopCapture()
        guard let start, end > start else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            throw Failure.noFrames
        }

        input.markAsFinished()
        audioInput?.markAsFinished()
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
        return Clip(video: writer.outputURL, seconds: (end - start).seconds, poster: poster, start: start)
    }

    /// Ends the recording and deletes its file.
    func discard() {
        queue.async { [self] in
            isStopped = true
        }
        Task {
            await stopCapture()
            queue.async { [self] in
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: writer.outputURL)
            }
        }
    }

    // MARK: - Frames (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen, Self.isComplete(buffer) {
            append(buffer)
            return
        }
        if #available(macOS 15.0, *), type == .microphone {
            appendAudio(buffer)
        }
    }

    /// Writes sound moved back by the time spent paused, from the clip's first frame on; sound
    /// during a pause, or that the encoder cannot take now, is dropped.
    private func appendAudio(_ buffer: CMSampleBuffer) {
        guard let audioInput, !isStopped, writer.status == .writing, let startTime, buffer.isValid,
              let time = videoTime(of: buffer.presentationTimeStamp), time >= startTime, audioInput.isReadyForMoreMediaData
        else {
            return
        }
        let offset = time - buffer.presentationTimeStamp
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + offset
            timings[index].decodeTimeStamp = .invalid
        }
        var moved: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &moved)
        if let moved, !audioInput.append(moved) {
            log.error("could not write sound: \(self.writer.error?.localizedDescription ?? "", privacy: .public)")
        }
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
        // A stopped, cancelled or failed writer throws on any call: nothing goes to it.
        guard !isStopped, writer.status == .writing, lastTime.map({ time > $0 }) ?? true, let frame = buffer.imageBuffer else {
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

#if DEBUG
extension ScreenRecorder {
    /// A recorder of `width` × `height` frames into `video` with no source, whose Resume
    /// pictures come from `takeStill` and whose source ends with `endCapture`. Debug builds only.
    static func forTesting(
        video: URL, width: Int, height: Int, takeStill: @escaping @Sendable () async -> CMSampleBuffer?, endCapture: @escaping () async -> Void = {}
    ) throws -> ScreenRecorder {
        let (writer, input, _) = try makeWriter(width: width, height: height, withAudio: false, to: video)
        let recorder = ScreenRecorder(clock: CMClockGetHostTimeClock(), writer: writer, input: input, audioInput: nil, onSourceEnded: {})
        recorder.takeStill = takeStill
        recorder.endCapture = endCapture
        return recorder
    }

    /// Returns once the recorder's queue has done what was asked of it before, such as the
    /// start of a pause. Debug builds only.
    func queueDoneForTesting() async {
        await withCheckedContinuation { done in
            queue.async {
                done.resume()
            }
        }
    }

    /// Whether a frame is in the clip, as the recorder's queue has it now. Debug builds only.
    func hasFrameForTesting() async -> Bool {
        await withCheckedContinuation { done in
            queue.async { [self] in
                done.resume(returning: lastTime != nil)
            }
        }
    }
}
#endif
