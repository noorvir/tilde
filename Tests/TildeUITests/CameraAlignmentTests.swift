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

    /// The camera file starts before the screen does: what came before the clip's first
    /// frame is cut off, and the rest starts at the clip's start.
    @Test func anEarlyCameraFileLosesItsHead() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("camera-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: file) }
        try await Self.writeMovie(to: file, seconds: 1)

        let clipStart = CMTime(seconds: 100, preferredTimescale: 600)
        let recording = CameraRecording(file: file, start: clipStart - CMTime(seconds: 0.5, preferredTimescale: 600))
        await CameraAlignment.align(recording, toClipStartingAt: clipStart)

        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 0.5) < 0.05, "\(duration)")
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            times.append(sample.presentationTimeStamp.seconds)
        }
        #expect(abs((times.first ?? 1)) < 0.02, "\(times.first ?? -1)")
        #expect((14...16).contains(times.count), "\(times.count)")
    }

    /// The saved video shows the camera from its first frame on, also before a late camera's
    /// own start: there its first frame stands in.
    @Test func theSavedVideoShowsALateCameraFromTheStart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("clip.mov")
        let camera = ClipRecorder.cameraFile(of: video)
        try await Self.writeMovie(to: video, seconds: 1)
        try await Self.writeMovie(to: camera, seconds: 1)
        let clipStart = CMTime(seconds: 100, preferredTimescale: 600)
        await CameraAlignment.align(CameraRecording(file: camera, start: clipStart + CMTime(seconds: 0.5, preferredTimescale: 600)), toClipStartingAt: clipStart)

        // The camera in a corner, on the background alone.
        var layout = ClipLayout(background: .gradient(.peach))
        layout.screenScale = 0.3
        layout.cameraCenter = CGPoint(x: 0.15, y: 0.8)
        let saved = folder.appendingPathComponent("saved.mp4")
        try await VideoFramer.export(video, camera: camera, layout: layout, to: saved)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: saved))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        let centre = try Self.brightness(of: frame, at: CGPoint(x: 0.15, y: 0.8))
        let background = try Self.brightness(of: frame, at: CGPoint(x: 0.9, y: 0.1))
        // The test movie's frames are black; the background is not.
        #expect(centre < 0.1, "\(centre)")
        #expect(background > 0.4, "\(background)")
    }

    /// 0 to 1 at a point given in fractions of the image, from its top-left corner.
    private static func brightness(of image: CGImage, at point: CGPoint) throws -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let x = point.x * CGFloat(image.width)
        let y = (1 - point.y) * CGFloat(image.height)
        context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }

    /// A window's clip is black outside the window's round corners: the mask takes the
    /// window's own radius. A frame with no black corner has none to take.
    @Test func theCornerIsMeasuredFromTheWindowsOwn() throws {
        func frame(radius: CGFloat) throws -> CGImage {
            let context = try #require(CGContext(
                data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let all = CGRect(x: 0, y: 0, width: 1600, height: 1000)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(all)
            // A dark window: well above black.
            context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
            context.addPath(CGPath(roundedRect: all, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            return try #require(context.makeImage())
        }

        let measured = try #require(VideoFramer.corner(of: try frame(radius: 32)))
        #expect(abs(measured * 1000 - 32) < 6, "\(measured * 1000)")
        #expect(VideoFramer.corner(of: try frame(radius: 0)) == nil)
    }

    /// Play right after the preview opens, before either file has loaded: both players wait,
    /// then run on the same time of the clip.
    @MainActor @Test func playStartsTheClipAndItsCameraInStep() async throws {
        let video = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        let cameraFile = ClipRecorder.cameraFile(of: video)
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: cameraFile)
        }
        try await Self.writeMovie(to: video, seconds: 2)
        try await Self.writeMovie(to: cameraFile, seconds: 2)

        let players = ClipPlayers(video: video, camera: cameraFile, seconds: 2)
        let camera = try #require(players.camera)
        players.toggle()
        let limit = Date().addingTimeInterval(5)
        while players.screen.currentTime().seconds < 0.3, Date() < limit {
            try await Task.sleep(for: .milliseconds(20))
        }
        let offset = (camera.currentTime() - players.screen.currentTime()).seconds
        players.stop()

        #expect(players.screen.currentTime().seconds >= 0.3)
        #expect(abs(offset) < 0.005, "\(offset)")
    }

    /// The scrubber's time: minutes and two-digit seconds, cut down to the second.
    @MainActor @Test func theScrubberShowsPlayedAndLength() {
        let clock = ClipClock()
        clock.duration = 75.6
        clock.played(to: 3.9)
        #expect(clock.text == "0:03 / 1:15")
        clock.isScrubbing = true
        clock.played(to: 9)
        #expect(clock.position == 3.9)
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
