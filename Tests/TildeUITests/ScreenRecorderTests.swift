@testable import TildeUI
import AVFoundation
import Foundation
import Testing

/// The picture that Resume takes arrives late: it goes in only for the stretch of recording it
/// was taken for, at the time it was taken, and never after Stop or Discard.
@Suite(.serialized)
struct ScreenRecorderTests {
    @Test func aResumePictureGoesInAtItsOwnTime() async throws {
        let gate = Gate()
        let recorder = try makeRecorder(gate: gate)

        recorder.pause()
        recorder.resume()
        // Resume's picture is taken after Resume, as the recorder asks for it then.
        await recorder.queueDoneForTesting()
        await gate.release(with: try picture(at: now()))
        try await eventually { await recorder.hasFrameForTesting() }

        let clip = try await recorder.stop()
        #expect(clip.seconds > 0)
    }

    @Test func aPictureFromALaterPauseNeverGoesIn() async throws {
        let gate = Gate()
        let recorder = try makeRecorder(gate: gate)

        recorder.pause()
        recorder.resume()
        try await Task.sleep(for: .milliseconds(20))
        recorder.pause()
        await recorder.queueDoneForTesting()
        let takenWhilePaused = try picture(at: now())
        recorder.resume()
        await gate.release(with: takenWhilePaused)
        try await Task.sleep(for: .milliseconds(200))

        await #expect(throws: ScreenRecorder.Failure.self) {
            try await recorder.stop()
        }
    }

    @Test func aPictureAfterStopOrDiscardIsDropped() async throws {
        let stopGate = Gate()
        let stopped = try makeRecorder(gate: stopGate)
        stopped.pause()
        stopped.resume()
        await #expect(throws: ScreenRecorder.Failure.self) {
            try await stopped.stop()
        }
        await stopGate.release(with: try picture(at: now()))

        let discardGate = Gate()
        let discarded = try makeRecorder(gate: discardGate)
        discarded.pause()
        discarded.resume()
        discarded.discard()
        await discardGate.release(with: try picture(at: now()))
        try await eventually { !FileManager.default.fileExists(atPath: discarded.video.path) }
    }

    /// Stop ends the clip before the capture has shut down: a Resume picture that arrives
    /// meanwhile, taken after Stop, shows what came on screen after it and never goes in.
    @Test func aPictureWhileTheCaptureShutsDownIsDropped() async throws {
        let gate = Gate()
        let shutDown = Gate()
        let recorder = try makeRecorder(gate: gate) {
            _ = await shutDown.wait()
        }
        recorder.pause()
        recorder.resume()

        let stopping = Task { try await recorder.stop() }
        while await !shutDown.isWaiting {
            try await Task.sleep(for: .milliseconds(10))
        }
        await gate.release(with: try picture(at: now()))
        try await Task.sleep(for: .milliseconds(200))
        await shutDown.release(with: try picture(at: now()))

        await #expect(throws: ScreenRecorder.Failure.self) {
            try await stopping.value
        }
    }

    /// Waits until `condition` holds, and expects it then: for at most 5 s, which only a
    /// recorder that never gets there needs.
    private func eventually(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<500 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition(), sourceLocation: sourceLocation)
    }

    private func makeRecorder(gate: Gate, endCapture: @escaping () async -> Void = {}) throws -> ScreenRecorder {
        let video = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-recorder-\(UUID().uuidString).mp4")
        return try ScreenRecorder.forTesting(video: video, width: 64, height: 64, takeStill: {
            await gate.wait()?.buffer
        }, endCapture: endCapture)
    }

    private func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    /// A 64 × 64 frame taken at `time` on the host clock, as ScreenCaptureKit's pictures are.
    private func picture(at time: CMTime) throws -> Picture {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels)
        let frame = try #require(pixels)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: frame, formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &buffer
        )
        return Picture(buffer: try #require(buffer))
    }
}

private struct Picture: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

/// Holds the recorder's pictures back: the first one asked for gets the test's picture.
private actor Gate {
    private var waiting: [CheckedContinuation<Picture?, Never>] = []
    private var given: Picture?

    func wait() async -> Picture? {
        if let given {
            self.given = nil
            return given
        }
        return await withCheckedContinuation { waiting.append($0) }
    }

    var isWaiting: Bool {
        !waiting.isEmpty
    }

    func release(with picture: Picture) async {
        // The recorder asks on its own queue; give it a moment to ask.
        for _ in 0..<50 where waiting.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if waiting.isEmpty {
            given = picture
        } else {
            waiting.removeFirst().resume(returning: picture)
        }
    }

    deinit {
        waiting.forEach { $0.resume(returning: nil) }
    }
}
