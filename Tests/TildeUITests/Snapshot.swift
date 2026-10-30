@testable import TildeUI
import AppKit
import SwiftUI
import Testing

/// Renders views offscreen and compares them with the reference PNGs in `Tests/Snapshots/`.
///
/// Images are drawn at 2× into an sRGB bitmap on an opaque grey background, so they do not
/// depend on the screen. Text rendering changes between macOS versions, so the references
/// belong to the macOS major version in `manifest.json`; run with `TILDE_RECORD_SNAPSHOTS=1`
/// to record them again. On a mismatch, `<name>.actual.png` and `<name>.diff.png` are written
/// to `.build/snapshot-failures/`.
@MainActor
enum Snapshot {
    static let scale = 2
    /// A channel may differ by this much (of 255) before the pixel counts as different.
    static let channelTolerance = 2
    /// At most this share of pixels may differ.
    static let maxDifferentRatio = 0.001

    static func assertView<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name = .darkAqua, named name: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let hosting = NSHostingView(rootView: view.transaction { $0.disablesAnimations = true })
        let image = try await render(hosting, size: size, appearance: appearance)
        try compare(image, named: name, sourceLocation: sourceLocation)
    }

    /// Renders an AppKit view that draws itself; `windowOrigin` places its offscreen window.
    static func assertDrawnView(_ view: NSView, size: CGSize, windowOrigin: NSPoint = .zero, named name: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let image = try await render(view, size: size, windowOrigin: windowOrigin)
        try compare(image, named: name, sourceLocation: sourceLocation)
    }

    // MARK: - Rendering

    /// Overlay scrollers whatever the Mac's scroll bar setting (it follows a connected mouse),
    /// so scroll views have the same width everywhere. SwiftUI reads the class property when
    /// it lays out, so setting the style on the views afterwards is too late.
    private static let fixesScrollerStyle: Void = {
        guard let original = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)),
              let fixed = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.tildeSnapshotScrollerStyle))
        else {
            return
        }
        method_exchangeImplementations(original, fixed)
    }()

    private static func render(_ view: NSView, size: CGSize, windowOrigin: NSPoint = .zero, appearance: NSAppearance.Name = .darkAqua) async throws -> CGImage {
        _ = fixesScrollerStyle
        let window = NSWindow(contentRect: NSRect(origin: windowOrigin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.setFrameOrigin(windowOrigin)
        view.layoutSubtreeIfNeeded()
        // Lets SwiftUI commit its layers; animations are off, so the result is final.
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()

        let context = try #require(bitmapContext(width: Int(size.width) * scale, height: Int(size.height) * scale))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        if let layer = view.layer {
            // Layers draw with a top-left origin here, like the e2e renderer.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            layer.render(in: context)
        } else {
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            view.displayIgnoringOpacity(view.bounds, in: graphics)
        }
        window.contentView = nil
        return try #require(context.makeImage())
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    // MARK: - Comparing

    private static var isRecording: Bool {
        ProcessInfo.processInfo.environment["TILDE_RECORD_SNAPSHOTS"] == "1"
    }

    private static var macOSVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    private static let testsFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let referenceFolder = testsFolder.appendingPathComponent("Snapshots")
    private static let failureFolder = testsFolder.deletingLastPathComponent().appendingPathComponent(".build/snapshot-failures")
    private static let manifest = referenceFolder.appendingPathComponent("manifest.json")

    private static func compare(_ image: CGImage, named name: String, sourceLocation: SourceLocation) throws {
        let reference = referenceFolder.appendingPathComponent("\(name).png")
        if isRecording {
            try FileManager.default.createDirectory(at: referenceFolder, withIntermediateDirectories: true)
            try png(image).write(to: reference)
            try Data("{ \"macOS\": \(macOSVersion) }\n".utf8).write(to: manifest)
            return
        }

        let recordedOn = (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifest))) as? [String: Int]
        // References belong to one macOS version: text and controls render differently on
        // others, so a comparison there says nothing. Other versions run the code and skip it.
        guard recordedOn?["macOS"] == macOSVersion else {
            print("Snapshot \(name) not compared: references are for another macOS version")
            return
        }
        guard let data = try? Data(contentsOf: reference), let expected = decode(data) else {
            Issue.record("No reference for \(name). Record it with TILDE_RECORD_SNAPSHOTS=1 swift test --filter SnapshotTests", sourceLocation: sourceLocation)
            return
        }

        let difference = try diff(image, expected)
        guard difference.ratio > maxDifferentRatio || difference.isDifferentSize else {
            return
        }

        try FileManager.default.createDirectory(at: failureFolder, withIntermediateDirectories: true)
        let actualURL = failureFolder.appendingPathComponent("\(name).actual.png")
        let diffURL = failureFolder.appendingPathComponent("\(name).diff.png")
        try png(image).write(to: actualURL)
        if let diffImage = difference.image {
            try png(diffImage).write(to: diffURL)
        }

        let summary: String
        if difference.isDifferentSize {
            summary = "size \(image.width)×\(image.height) px, reference \(expected.width)×\(expected.height) px"
        } else {
            summary = String(format: "%.2f%% of pixels differ (limit %.2f%%)", difference.ratio * 100, maxDifferentRatio * 100)
        }
        Issue.record("Snapshot \(name) differs: \(summary).\n  actual: \(actualURL.path)\n  diff:   \(diffURL.path)", sourceLocation: sourceLocation)
    }

    private struct Difference {
        let ratio: Double
        let isDifferentSize: Bool
        /// The reference in grey with differing pixels in red.
        let image: CGImage?
    }

    private static func diff(_ actual: CGImage, _ expected: CGImage) throws -> Difference {
        guard actual.width == expected.width, actual.height == expected.height else {
            return Difference(ratio: 1, isDifferentSize: true, image: nil)
        }

        let width = actual.width
        let height = actual.height
        let actualPixels = try pixels(of: actual)
        let expectedPixels = try pixels(of: expected)
        if actualPixels == expectedPixels {
            return Difference(ratio: 0, isDifferentSize: false, image: nil)
        }
        var diffPixels = [UInt8](repeating: 255, count: width * height * 4)
        var different = 0

        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            var isDifferent = false
            for channel in 0..<4 where abs(Int(actualPixels[offset + channel]) - Int(expectedPixels[offset + channel])) > channelTolerance {
                isDifferent = true
            }
            if isDifferent {
                different += 1
                diffPixels[offset] = 255
                diffPixels[offset + 1] = 0
                diffPixels[offset + 2] = 0
            } else {
                let grey = UInt8((Int(expectedPixels[offset]) + Int(expectedPixels[offset + 1]) + Int(expectedPixels[offset + 2])) / 6 + 64)
                diffPixels[offset] = grey
                diffPixels[offset + 1] = grey
                diffPixels[offset + 2] = grey
            }
        }

        let context = bitmapContext(width: width, height: height)
        context?.data?.copyMemory(from: diffPixels, byteCount: diffPixels.count)
        return Difference(ratio: Double(different) / Double(width * height), isDifferentSize: false, image: context?.makeImage())
    }

    /// RGBA bytes of an image drawn into the same sRGB format, so both sides compare alike.
    private static func pixels(of image: CGImage) throws -> [UInt8] {
        let context = try #require(bitmapContext(width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        return [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private static func png(_ image: CGImage) throws -> Data {
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private extension NSScroller {
    @objc class var tildeSnapshotScrollerStyle: NSScroller.Style { .overlay }
}
