import AppKit
import ScreenCaptureKit

/// A tiny greyscale picture of what a note is on, to tell whether that content is still on
/// screen in apps that do not describe their contents, such as the iOS Simulator.
struct NoteFingerprint: Equatable, Sendable {
    /// The longer side of the picture, in pixels. Sharp enough to read: small text on rows of
    /// the same layout must look different.
    static let longestSide: CGFloat = 400
    /// Points of surroundings around the note's area: a small piece of text alone looks like
    /// any other, while its surroundings tell pages apart.
    static let context: CGFloat = 40
    /// Grey levels, row by row.
    let levels: [UInt8]

    /// How alike two pictures are in structure, from 0 to 1. It compares the pattern of light
    /// and dark, not overall brightness: different text on the same background has about the
    /// same brightness but another pattern. Plain areas have no pattern, so they compare by
    /// brightness.
    func similarity(to other: NoteFingerprint) -> Double {
        guard levels.count == other.levels.count, !levels.isEmpty else {
            return 0
        }
        let count = Double(levels.count)
        let meanA = levels.reduce(0.0) { $0 + Double($1) } / count
        let meanB = other.levels.reduce(0.0) { $0 + Double($1) } / count
        var covariance = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for (a, b) in zip(levels, other.levels) {
            let (x, y) = (Double(a) - meanA, Double(b) - meanB)
            covariance += x * y
            varianceA += x * x
            varianceB += y * y
        }
        let isPlainA = (varianceA / count).squareRoot() < 3
        let isPlainB = (varianceB / count).squareRoot() < 3
        if isPlainA && isPlainB {
            return max(0, 1 - abs(meanA - meanB) / 255 * 8)
        }
        if isPlainA || isPlainB {
            return 0
        }
        return max(0, covariance / (varianceA * varianceB).squareRoot())
    }

    /// Scales any image down to a fingerprint.
    init?(image: CGImage) {
        let (width, height) = (image.width, image.height)
        var levels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = levels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            return nil
        }
        self.levels = levels
    }

    init(levels: [UInt8]) {
        self.levels = levels
    }

    /// The area of a window, without anything in front of it. Nil without Screen Recording or
    /// when the window is gone.
    /// `windowFrame`: where the window is now, if known; its description can be from earlier.
    static func capture(window windowID: CGWindowID, area: CGRect, windowFrame: CGRect? = nil) async -> NoteFingerprint? {
        guard let window = await CapturableWindows.shared.window(windowID) else {
            return nil
        }
        let frame = windowFrame ?? window.frame
        let rect = area.insetBy(dx: -context, dy: -context).intersection(frame)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
            return nil
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let scale = min(2, longestSide / max(rect.width, rect.height))
        configuration.width = Int(rect.width * scale)
        configuration.height = Int(rect.height * scale)
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            await CapturableWindows.shared.forget(windowID)
            return nil
        }
        return NoteFingerprint(image: image)
    }
}

/// Whether a note's content is on screen, from how alike its area is to its fingerprint over
/// time. Two thresholds and two readings in a row keep it from flickering.
struct NoteVisibility: Equatable, Codable {
    static let hideBelow = 0.97
    static let showAbove = 0.985
    static let readingsToChange = 2

    private(set) var isVisible = true
    private var readings = 0

    /// Takes a new similarity and returns whether the note shows.
    mutating func update(similarity: Double) -> Bool {
        let wantsChange = isVisible ? similarity < Self.hideBelow : similarity > Self.showAbove
        readings = wantsChange ? readings + 1 : 0
        if readings >= Self.readingsToChange {
            isVisible.toggle()
            readings = 0
        }
        return isVisible
    }
}

/// Remembers window descriptions: asking for all of them on every check is heavy for the system.
private actor CapturableWindows {
    static let shared = CapturableWindows()
    private var windows: [CGWindowID: SCWindow] = [:]

    func window(_ id: CGWindowID) async -> SCWindow? {
        if let window = windows[id] {
            return window
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        return windows[id]
    }

    func forget(_ id: CGWindowID) {
        windows[id] = nil
    }
}
