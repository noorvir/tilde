import AppKit
import ScreenCaptureKit

/// A tiny greyscale picture of what a note is on, to tell whether that content is still on
/// screen in apps that do not describe their contents, such as the iOS Simulator.
struct NoteFingerprint: Equatable, Sendable {
    static let side = 16
    /// Grey levels, row by row.
    let levels: [UInt8]

    /// How different two pictures are, from 0 (same) to 1.
    func difference(from other: NoteFingerprint) -> Double {
        guard levels.count == other.levels.count, !levels.isEmpty else {
            return 1
        }
        let total = zip(levels, other.levels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(levels.count) / 255
    }

    /// Scales any image down to a fingerprint.
    init?(image: CGImage) {
        let side = Self.side
        var levels = [UInt8](repeating: 0, count: side * side)
        let drawn: Bool = levels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
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
    static func capture(window windowID: CGWindowID, area: CGRect) async -> NoteFingerprint? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID })
        else {
            return nil
        }
        let rect = area.intersection(window.frame)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
            return nil
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        configuration.width = side
        configuration.height = side
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            return nil
        }
        return NoteFingerprint(image: image)
    }
}

/// Whether a note's content is on screen, from its fingerprint differences over time. Two
/// thresholds and two readings in a row keep it from flickering.
struct NoteVisibility: Equatable {
    static let hideAbove = 0.12
    static let showBelow = 0.1
    static let readingsToChange = 2

    private(set) var isVisible = true
    private var readings = 0

    /// Takes a new difference and returns whether the note shows.
    mutating func update(difference: Double) -> Bool {
        let wantsChange = isVisible ? difference > Self.hideAbove : difference < Self.showBelow
        readings = wantsChange ? readings + 1 : 0
        if readings >= Self.readingsToChange {
            isVisible.toggle()
            readings = 0
        }
        return isVisible
    }
}
