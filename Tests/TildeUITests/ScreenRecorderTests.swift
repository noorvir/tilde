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
        await gate.release(with: try picture(at: now()))
        try await Task.sleep(for: .milliseconds(200))

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
        try await Task.sleep(for: .milliseconds(20))
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
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: discarded.video.path))
    }

    private func makeRecorder(gate: Gate) throws -> ScreenRecorder {
        let video = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-recorder-\(UUID().uuidString).mp4")
        return try ScreenRecorder.forTesting(video: video, width: 64, height: 64) {
            await gate.wait()?.buffer
        }
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
