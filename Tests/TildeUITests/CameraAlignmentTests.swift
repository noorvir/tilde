import AVFoundation
import Foundation
import Testing
@testable import TildeUI

struct CameraAlignmentTests {
    /// A camera that started after the clip waits that long; one that started before loses its
    /// first part; less than a frame changes nothing.
    @Test func theOffsetBecomesAGapOrACut() {
        #expect(CameraAlignment.edit(offset: 0.4) == CameraAlignment.Edit(emptyAtStart: 0.4, trimmedAtStart: 0))
        #expect(CameraAlignment.edit(offset: -0.25) == CameraAlignment.Edit(emptyAtStart: 0, trimmedAtStart: 0.25))
        #expect(CameraAlignment.edit(offset: 0.01) == nil)
    }

    /// The file is rewritten in place: a camera that started 0.5 s late first shows at 0.5 s
    /// of the clip, and lasts that much longer.
    @Test func aLateCameraFileStartsLaterOnTheClip() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("camera-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: file) }
        try await Self.writeMovie(to: file, seconds: 1)

        let clipStart = CMTime(seconds: 100, preferredTimescale: 600)
        let recording = CameraRecording(file: file, start: clipStart + CMTime(seconds: 0.5, preferredTimescale: 600))
        await CameraAlignment.align(recording, toClipStartingAt: clipStart)

        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.5) < 0.05, "\(duration)")
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let segments = try await track.load(.segments)
        #expect(segments.first?.isEmpty == true)
        #expect(abs((segments.first?.timeMapping.target.duration.seconds ?? 0) - 0.5) < 0.01)
    }

    /// One second of small frames at 30 a second.
    private static func writeMovie(to file: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<(30 * seconds) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(30 * seconds), timescale: 30))
        await writer.finishWriting()
    }
}
