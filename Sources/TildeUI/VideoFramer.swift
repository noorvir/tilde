import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Writes a screen clip and its camera on a background, as a 1920 × 1080 MP4 with the clip's
/// sound.
enum VideoFramer {
    static let canvas = CGSize(width: 1920, height: 1080)

    enum Failure: Error {
        case noBackground, noVideo, exportFailed
    }

    static func export(_ video: URL, camera: URL?, layout: ClipLayout, to file: URL) async throws {
        guard let backdrop = image(of: layout.background) else {
            throw Failure.noBackground
        }
        let screenAsset = AVURLAsset(url: video)
        guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideo
        }
        let duration = try await screenAsset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        guard let screenPart = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.exportFailed
        }
        try screenPart.insertTimeRange(range, of: screenTrack, at: .zero)
        for audio in try await screenAsset.loadTracks(withMediaType: .audio) {
            let part = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try part?.insertTimeRange(range, of: audio, at: .zero)
        }

        var cameraPart: AVMutableCompositionTrack?
        var cameraStill: CIImage?
        if let camera, layout.cameraCenter != nil {
            let cameraAsset = AVURLAsset(url: camera)
            if let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first {
                let cameraDuration = try await cameraAsset.load(.duration)
                let part = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try part?.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, cameraDuration)), of: cameraTrack, at: .zero)
                cameraPart = part
                let still = await firstFrame(of: camera)
                cameraStill = still.map { CIImage(cgImage: $0) }
            }
        }

        let clipSize = try await screenTrack.load(.naturalSize)
        let corner = await corner(of: video)
        let instruction = FrameInstruction(
            timeRange: range, screenID: screenPart.trackID, cameraID: cameraPart?.trackID, cameraStill: cameraStill, layout: layout, clipSize: clipSize,
            corner: corner, backdrop: backdrop
        )
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = FrameCompositor.self
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed
        }
        session.outputURL = file
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        await session.export()
        guard session.status == .completed else {
            throw session.error ?? Failure.exportFailed
        }
    }

    /// The corner radius for a clip with no measured one, in fractions of its shorter side.
    static let defaultCorner: CGFloat = 0.025

    /// The corner radius of what a clip shows, in fractions of the clip's shorter side. A
    /// window's clip is black outside the window's round corners: the radius is measured there
    /// on the first frame, so the mask cuts off the black and nothing of the window. A clip
    /// with no black corner, such as a screen's, gets `defaultCorner`.
    static func corner(of video: URL) async -> CGFloat {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        guard let first = try? await generator.image(at: .zero) else {
            return defaultCorner
        }
        return corner(of: first.image) ?? defaultCorner
    }

    /// Nil when neither top corner is black, or the black goes too far to be a corner.
    static func corner(of frame: CGImage) -> CGFloat? {
        let shorter = CGFloat(min(frame.width, frame.height))
        // Far enough along the diagonal for a radius of a tenth of the shorter side.
        let side = Int(shorter * 0.04) + 2
        guard side < frame.width / 2, side < frame.height / 2,
              let left = blackSteps(in: frame, fromLeft: true, side: side),
              let right = blackSteps(in: frame, fromLeft: false, side: side)
        else {
            return nil
        }
        let steps = min(left, right)
        guard steps > 0, steps < side else {
            return nil
        }
        // A circle's edge crosses the diagonal at r × (1 − 1/√2) from the corner; one pixel
        // more covers the blended edge.
        let radius = CGFloat(steps + 1) / (1 - 1 / 2.0.squareRoot())
        return radius / shorter
    }

    /// How many pixels are black along the diagonal from a top corner of `frame`, in a square
    /// of `side` pixels.
    private static func blackSteps(in frame: CGImage, fromLeft: Bool, side: Int) -> Int? {
        let x = fromLeft ? 0 : frame.width - side
        guard let corner = frame.cropping(to: CGRect(x: x, y: 0, width: side, height: side)),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        context.draw(corner, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else {
            return nil
        }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var steps = 0
        // The bitmap's first row is the image's top row.
        while steps < side {
            let column = fromLeft ? steps : side - 1 - steps
            let offset = (steps * side + column) * 4
            // An encoded black is not exactly zero; a dark window is well above this.
            guard max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) < 12 else {
                break
            }
            steps += 1
        }
        return steps
    }

    /// A camera file's first frame. A camera that started after the clip has nothing before
    /// it: the preview and the saved video show this frame there.
    static func firstFrame(of file: URL) async -> CGImage? {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, let segments = try? await track.load(.segments) else {
            return nil
        }
        let start = segments.first { !$0.isEmpty }?.timeMapping.target.start ?? .zero
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        let image = try? await generator.image(at: start)
        return image?.image
    }

    /// One frame: the background, the screen clip rounded with a shadow, and the camera in
    /// its shape, mirrored, with a white rim.
    fileprivate static func frame(_ instruction: FrameInstruction, screen: CIImage, camera: CIImage?) -> CIImage {
        let layout = instruction.layout
        let frames = layout.frames(in: canvas, clip: instruction.clipSize)
        var result = instruction.backdrop

        let screenRect = flipped(frames.screen)
        let placed = fit(screen, in: screenRect)
        let radius = min(screenRect.width, screenRect.height) * instruction.corner
        result = shadow(of: screenRect, radius: radius).composited(over: result)
        result = masked(placed, to: screenRect, radius: radius).composited(over: result)

        if let camera, let cameraFrame = frames.camera {
            let cameraRect = flipped(cameraFrame)
            let extent = camera.extent
            let side = min(extent.width, extent.height)
            let square = camera
                .cropped(to: CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side))
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            let cameraRadius = layout.cameraShape == .circle ? cameraRect.width / 2 : cameraRect.width * 0.2
            let rim: CGFloat = max(2, cameraRect.width * 0.012)
            let rimRect = cameraRect.insetBy(dx: -rim, dy: -rim)
            result = shadow(of: rimRect, radius: cameraRadius + rim).composited(over: result)
            result = solid(rimRect, radius: cameraRadius + rim, color: .white).composited(over: result)
            result = masked(fit(square, in: cameraRect), to: cameraRect, radius: cameraRadius).composited(over: result)
        }
        return result.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// A top-left rect on the canvas in Core Image's bottom-left coordinates.
    private static func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func fit(_ image: CIImage, in rect: CGRect) -> CIImage {
        let extent = image.extent
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: rect.width / extent.width, y: rect.height / extent.height))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    private static func solid(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let shape = CIFilter.roundedRectangleGenerator()
        shape.extent = rect
        shape.radius = Float(radius)
        shape.color = color
        return shape.outputImage ?? CIImage.empty()
    }

    private static func masked(_ image: CIImage, to rect: CGRect, radius: CGFloat) -> CIImage {
        let mask = solid(rect, radius: radius, color: .white)
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
    }

    private static func shadow(of rect: CGRect, radius: CGFloat) -> CIImage {
        solid(rect.offsetBy(dx: 0, dy: -12), radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)).applyingGaussianBlur(sigma: 24)
    }

    /// The background at the canvas size: a gradient, or an image that fills it.
    static func image(of background: VideoBackground) -> CIImage? {
        switch background {
        case .gradient(let gradient):
            return gradientImage(gradient, size: canvas).map(CIImage.init(cgImage:))
        case .image(let url):
            guard let image = CIImage(contentsOf: url) else {
                return nil
            }
            let extent = image.extent
            let scale = max(canvas.width / extent.width, canvas.height / extent.height)
            let width = extent.width * scale
            let height = extent.height * scale
            return image
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (canvas.width - width) / 2, y: (canvas.height - height) / 2))
                .cropped(to: CGRect(origin: .zero, size: canvas))
        }
    }

    static func gradientImage(_ gradient: VideoGradient, size: CGSize) -> CGImage? {
        let colors = gradient.cgColors
        let locations = colors.indices.map { CGFloat($0) / CGFloat(max(colors.count - 1, 1)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cgGradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations),
              let context = CGContext(
                  data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        // Quartz's origin is the bottom-left: the top-left corner is at the full height.
        context.drawLinearGradient(cgGradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        return context.makeImage()
    }
}

/// The whole clip's composition: which tracks, and where they go. It does not change once
/// made, so the compositor's threads may share it.
private final class FrameInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenID: CMPersistentTrackID
    let cameraID: CMPersistentTrackID?
    /// The camera's first frame, for the times its track has none.
    let cameraStill: CIImage?
    let layout: ClipLayout
    let clipSize: CGSize
    /// The screen clip's corner radius, in fractions of its shorter side.
    let corner: CGFloat
    let backdrop: CIImage

    init(
        timeRange: CMTimeRange, screenID: CMPersistentTrackID, cameraID: CMPersistentTrackID?, cameraStill: CIImage?, layout: ClipLayout, clipSize: CGSize,
        corner: CGFloat, backdrop: CIImage
    ) {
        self.timeRange = timeRange
        self.screenID = screenID
        self.cameraID = cameraID
        self.cameraStill = cameraStill
        self.layout = layout
        self.clipSize = clipSize
        self.corner = corner
        self.backdrop = backdrop
        requiredSourceTrackIDs = [screenID, cameraID].compactMap { $0 }.map { NSNumber(value: $0) }
    }
}

private final class FrameCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let context = CIContext()
    private static let pixelFormat: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    let sourcePixelBufferAttributes: [String: any Sendable]? = FrameCompositor.pixelFormat
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = FrameCompositor.pixelFormat

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? FrameInstruction,
              let screen = request.sourceFrame(byTrackID: instruction.screenID),
              let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: VideoFramer.Failure.exportFailed)
            return
        }
        let cameraFrame = instruction.cameraID.flatMap(request.sourceFrame(byTrackID:)).map { CIImage(cvPixelBuffer: $0) }
        let camera = cameraFrame ?? instruction.cameraStill
        let image = VideoFramer.frame(instruction, screen: CIImage(cvPixelBuffer: screen), camera: camera)
        Self.context.render(image, to: output)
        request.finish(withComposedVideoFrame: output)
    }
}
