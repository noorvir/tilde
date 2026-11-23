import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// What a saved camera video sits on: the clip centred, with rounded corners and a shadow.
enum VideoBackground: Equatable {
    /// The clip as recorded, with no frame.
    case none
    case gradient(VideoGradient)
    /// An image the user added, in `VideoBackground.folder`.
    case image(URL)

    /// The user's own backgrounds.
    static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tilde/Backgrounds", isDirectory: true)
    }()

    /// As kept in the defaults: "none", "gradient:<name>" or "image:<file name>".
    var key: String {
        switch self {
        case .none: "none"
        case .gradient(let gradient): "gradient:\(gradient.rawValue)"
        case .image(let url): "image:\(url.lastPathComponent)"
        }
    }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("none", 1):
            self = .none
        case ("gradient", 2):
            guard let gradient = VideoGradient(rawValue: parts[1]) else {
                return nil
            }
            self = .gradient(gradient)
        case ("image", 2):
            let url = Self.folder.appendingPathComponent(parts[1])
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            self = .image(url)
        default:
            return nil
        }
    }
}

enum VideoGradient: String, CaseIterable {
    case dusk, ocean, peach, aurora, graphite

    var name: String {
        rawValue.capitalized
    }

    /// From the top-left corner to the bottom-right, as "#RRGGBB".
    var colors: [String] {
        switch self {
        case .dusk: ["#3B5BA9", "#8A5FA8", "#D9897A"]
        case .ocean: ["#0F2027", "#2C5364", "#4CA1AF"]
        case .peach: ["#FFB88C", "#F08A7E", "#DE6262"]
        case .aurora: ["#1FA2FF", "#12D8FA", "#A6FFCB"]
        case .graphite: ["#1C1D21", "#3A3D45", "#5B5F6B"]
        }
    }

    var cgColors: [CGColor] {
        colors.map { hex in
            let value = Int(hex.dropFirst(), radix: 16) ?? 0
            return CGColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

/// Writes a clip centred on a background, as a 1920 × 1080 MP4 with the clip's sound.
enum VideoFramer {
    static let canvas = CGSize(width: 1920, height: 1080)
    /// The share of the canvas the clip may take on each axis.
    private static let fill: CGFloat = 0.86

    enum Failure: Error {
        case noBackground, exportFailed
    }

    static func export(_ video: URL, on background: VideoBackground, to file: URL) async throws {
        guard background != .none else {
            try FileManager.default.copyItem(at: video, to: file)
            return
        }
        guard let image = image(of: background) else {
            throw Failure.noBackground
        }
        let backdrop = Backdrop(image: image)
        let asset = AVURLAsset(url: video)
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let framed = frame(request.sourceImage, on: backdrop.image).cropped(to: canvasRect)
            request.finish(with: framed, context: nil)
        }
        composition.renderSize = canvas

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed
        }
        session.outputURL = file
        session.outputFileType = .mp4
        session.videoComposition = composition
        await session.export()
        guard session.status == .completed else {
            throw session.error ?? Failure.exportFailed
        }
    }

    /// A CIImage does not change once made, so the frames' handler may share it.
    private struct Backdrop: @unchecked Sendable {
        let image: CIImage
    }

    /// The clip scaled to fit, centred, with rounded corners and a soft shadow, on the backdrop.
    private static func frame(_ clip: CIImage, on backdrop: CIImage) -> CIImage {
        let source = clip.extent
        let scale = min(canvas.width * fill / source.width, canvas.height * fill / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        let rect = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
        let placed = clip
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))

        let corners = CIFilter.roundedRectangleGenerator()
        corners.extent = rect
        corners.radius = Float(min(rect.width, rect.height) * 0.025)
        corners.color = .white
        let mask = corners.outputImage ?? CIImage(color: .white).cropped(to: rect)

        let shade = CIFilter.roundedRectangleGenerator()
        shade.extent = rect.offsetBy(dx: 0, dy: -14)
        shade.radius = corners.radius
        shade.color = CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)
        let shadow = (shade.outputImage ?? CIImage.empty()).applyingGaussianBlur(sigma: 28)

        let rounded = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        return rounded.composited(over: shadow.composited(over: backdrop))
    }

    /// The background at the canvas size: a gradient, or an image that fills it.
    static func image(of background: VideoBackground) -> CIImage? {
        switch background {
        case .none:
            return nil
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
